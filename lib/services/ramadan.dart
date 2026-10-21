import 'package:hijri/hijri_calendar.dart';

/// Where today sits relative to Ramadan, in the app's own calendar.
///
/// Everything here is read off the same Umm al-Qura table the Home greeting
/// and the calendar screen use, so the banner that says "Day 12 of Ramadan"
/// and the Hijri date above it can never disagree by a day.
class RamadanInfo {
  const RamadanInfo({
    required this.start,
    required this.lastDay,
    required this.length,
    this.dayNumber,
  });

  /// First gregorian day of Ramadan, at midnight.
  final DateTime start;

  /// Last gregorian day of Ramadan, at midnight (inclusive).
  final DateTime lastDay;

  /// 29 or 30 — the month's real length for this year, not an average.
  final int length;

  /// Which day of the fast today is (1-based); `null` once Ramadan is over.
  final int? dayNumber;

  /// Whether [day] is inside the fast.
  bool get isRunning => dayNumber != null;
}

/// Looks up where [day] sits relative to the Ramadan of its Hijri year.
///
/// [adjustment] is the same ±days the Settings screen applies to every Hijri
/// reading, so a user who has corrected their calendar by one day sees the
/// banner correct by one day too.
///
/// Returns `null` for a day that is not in Ramadan — which is most days, and
/// is why the Home card draws nothing at all then.
RamadanInfo? ramadanAround(DateTime day, {int adjustment = 0}) {
  final DateTime shifted = day.add(Duration(days: adjustment));
  final HijriCalendar h = HijriCalendar.fromDate(shifted);

  if (h.hMonth == Ramadan.month) {
    final int length = h.getDaysInMonth(h.hYear, Ramadan.month);
    final DateTime start = _gregorianOf(h.hYear, Ramadan.month, 1, adjustment);
    return RamadanInfo(
      start: start,
      lastDay: start.add(Duration(days: length - 1)),
      length: length,
      dayNumber: h.hDay,
    );
  }

  return null;
}

/// How many days until Ramadan begins, or `null` when it is running.
///
/// Negative never happens: a past Ramadan belongs to its own year's lookup.
int? daysUntilRamadan(DateTime day, {int adjustment = 0}) {
  final DateTime start = ramadanStartNear(day, adjustment: adjustment);
  final DateTime midnight = DateTime(day.year, day.month, day.day);
  final int days = start.difference(midnight).inDays;
  return days < 0 ? null : days;
}

/// The start of the Ramadan that is running now, or the next one to come.
DateTime ramadanStartNear(DateTime day, {int adjustment = 0}) {
  final DateTime shifted = day.add(Duration(days: adjustment));
  final HijriCalendar h = HijriCalendar.fromDate(shifted);
  if (h.hMonth < Ramadan.month) {
    return _gregorianOf(h.hYear, Ramadan.month, 1, adjustment);
  }
  return _gregorianOf(h.hYear + 1, Ramadan.month, 1, adjustment);
}

/// The Hijri month of the fast itself.
class Ramadan {
  Ramadan._();

  static const int month = 9;
  static const int shawwal = 10;
}

/// Converts a Hijri date back to the gregorian day the app should *show* it
/// on, undoing the same [adjustment] that was applied on the way in — so
/// `hijri → gregorian → hijri` round-trips to the date the user typed.
DateTime _gregorianOf(int year, int month, int day, int adjustment) {
  final DateTime raw = HijriCalendar().hijriToGregorian(year, month, day);
  final DateTime midnight = DateTime(raw.year, raw.month, raw.day);
  return midnight.subtract(Duration(days: adjustment));
}
