import 'package:hijri/hijri_calendar.dart';

/// The Islamic calendar as a *screen* understands it: which Hijri month a
/// gregorian day belongs to, which days of it carry an event, and what comes
/// next.
///
/// The conversion machinery is the Umm al-Qura table inside the `hijri`
/// package — the same one the Home greeting prints — and the user's ±days
/// correction is applied on the way in and undone on the way out, so a grid
/// cell and the gregorian date printed under it can never drift apart.
class NoorHijri {
  NoorHijri._();

  /// The Hijri reading the app shows for a gregorian day — the exact
  /// conversion `HomeScreen._greetingSub` performs, lifted here so the two
  /// can never disagree.
  static HijriCalendar hijriOf(DateTime day, {int adjustment = 0}) =>
      HijriCalendar.fromDate(day.add(Duration(days: adjustment)));

  /// The gregorian day a Hijri date falls on, with [adjustment] undone.
  static DateTime gregorianOf(int year, int month, int day,
      {int adjustment = 0}) {
    final DateTime raw = HijriCalendar().hijriToGregorian(year, month, day);
    return DateTime(raw.year, raw.month, raw.day)
        .subtract(Duration(days: adjustment));
  }

  /// First gregorian day of the Hijri month [day] falls in.
  static DateTime monthStart(DateTime day, {int adjustment = 0}) {
    final HijriCalendar h = hijriOf(day, adjustment: adjustment);
    return gregorianOf(h.hYear, h.hMonth, 1, adjustment: adjustment);
  }

  /// How many days the Hijri month holding [day] has — 29 or 30, the real
  /// length from the table rather than an average month.
  static int monthLength(DateTime day, {int adjustment = 0}) {
    final HijriCalendar h = hijriOf(day, adjustment: adjustment);
    return h.getDaysInMonth(h.hYear, h.hMonth);
  }

  /// The first day of the Hijri month [delta] months from the one holding
  /// [day] — negative walks back. Navigating by *month* rather than by a
  /// fixed 29/30-day hop is what keeps "next month" landing on the 1st.
  static DateTime monthStartBy(DateTime day, int delta,
      {int adjustment = 0}) {
    final HijriCalendar h = hijriOf(day, adjustment: adjustment);
    final int zeroBased = h.hYear * 12 + (h.hMonth - 1) + delta;
    final int year = zeroBased ~/ 12;
    final int month = zeroBased % 12 + 1;
    return gregorianOf(year, month, 1, adjustment: adjustment);
  }
}

/// One day of a month grid, in both calendars at once.
class HijriGridDay {
  const HijriGridDay({
    required this.gregorian,
    required this.hijriDay,
    required this.isToday,
    required this.events,
  });

  /// The gregorian midnight this cell stands for.
  final DateTime gregorian;

  /// Its day of the Hijri month, 1-based — the number printed large.
  final int hijriDay;

  final bool isToday;

  /// Named occasions landing on this day; usually none.
  final List<IslamicEvent> events;
}

/// Builds the cells for the Hijri month holding [anchor].
///
/// The grid is exactly one Hijri month long, so it starts on that month's
/// 1st (a gregorian day that may sit in the previous calendar month — the
/// number under it says so) and runs to its last. Every cell knows both of
/// its dates, which is the whole point of the screen.
List<HijriGridDay> hijriMonthGrid(DateTime anchor, {int adjustment = 0}) {
  final HijriCalendar h = NoorHijri.hijriOf(anchor, adjustment: adjustment);
  final DateTime start =
      NoorHijri.gregorianOf(h.hYear, h.hMonth, 1, adjustment: adjustment);
  final int length = h.getDaysInMonth(h.hYear, h.hMonth);
  final DateTime today =
      DateTime(anchor.year, anchor.month, anchor.day);

  return List<HijriGridDay>.generate(length, (int i) {
    final DateTime day = start.add(Duration(days: i));
    return HijriGridDay(
      gregorian: day,
      hijriDay: i + 1,
      isToday: day == today,
      events: eventsOn(day, adjustment: adjustment),
    );
  });
}

/// One named occasion, on a fixed Hijri date every year.
class IslamicEvent {
  const IslamicEvent(this.month, this.day, this.title, {this.note = ''});

  final int month;
  final int day;
  final String title;

  /// One line under the title — the rule or the caution, since several of
  /// these dates are *one* widely followed sighting among others and the
  /// screen should say so rather than pronounce.
  final String note;

  bool get isEid => title.contains('Eid');
}

/// The fixed-date occasions the calendar marks.
///
/// Every entry sits on the Hijri date *most* of the subcontinent writes on
/// its boards. Moon-sighting can move any of them by a day, which is exactly
/// what the notes say and what the user's own ±days correction is for — this
/// list is a calendar, not a fatwa.
const List<IslamicEvent> kIslamicEvents = <IslamicEvent>[
  IslamicEvent(1, 1, 'Islamic New Year', note: '1 Muharram'),
  IslamicEvent(1, 10, 'Ashura', note: '10 Muharram — the day of'),
  IslamicEvent(3, 12, 'Milad un Nabi', note: '12 Rabi al-Awwal'),
  IslamicEvent(7, 27, 'Isra wal Miraj', note: '27 Rajab — the Night Journey'),
  IslamicEvent(8, 15, 'Shab-e-Barat', note: '15 Sha\'ban — the night of'),
  IslamicEvent(9, 1, 'Ramadan begins', note: '1 Ramadan — the first fast'),
  IslamicEvent(9, 27, 'Laylat al-Qadr', note: '27 Ramadan — one of the last ten nights'),
  IslamicEvent(10, 1, 'Eid al-Fitr', note: '1 Shawwal — moon sighting may move it'),
  IslamicEvent(12, 9, 'Day of Arafah', note: '9 Dhul Hijjah — the fast of'),
  IslamicEvent(12, 10, 'Eid al-Adha', note: '10 Dhul Hijjah — moon sighting may move it'),
];

/// The occasions falling on a specific Hijri month/day.
List<IslamicEvent> eventsOnHijri(int month, int day) => kIslamicEvents
    .where((IslamicEvent e) => e.month == month && e.day == day)
    .toList(growable: false);

/// The occasions falling on a gregorian day.
List<IslamicEvent> eventsOn(DateTime day, {int adjustment = 0}) {
  final HijriCalendar h = NoorHijri.hijriOf(day, adjustment: adjustment);
  return eventsOnHijri(h.hMonth, h.hDay);
}

/// The next occasion at or after [from] — the countdown line at the top of
/// the calendar screen.
///
/// Looks up to [windowDays] ahead; Islamic years are ~11 days shorter than
/// gregorian ones, so 400 comfortably covers "nothing left this year".
(IslamicEvent, DateTime)? nextEvent(DateTime from, {int adjustment = 0, int windowDays = 400}) {
  final DateTime start = DateTime(from.year, from.month, from.day);
  for (int i = 0; i <= windowDays; i++) {
    final DateTime day = start.add(Duration(days: i));
    final List<IslamicEvent> hits = eventsOn(day, adjustment: adjustment);
    if (hits.isNotEmpty) return (hits.first, day);
  }
  return null;
}

/// `Ramadan begins` is also the first day of the fast itself — the Ramadan
/// banner owns that meaning, so the calendar does not double it into a
/// second countdown. Used by the calendar header to prefer the *next*
/// occasion that is not that one... kept as a helper so the policy has one
/// home rather than being spelled in the screen.
bool isRamadanStart(IslamicEvent event) => event.month == 9 && event.day == 1;
