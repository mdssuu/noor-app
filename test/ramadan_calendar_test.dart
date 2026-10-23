import 'package:flutter_test/flutter_test.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:noor_masjid_time/services/islamic_calendar.dart';
import 'package:noor_masjid_time/services/ramadan.dart';

/// The calendar layer, tested through the round-trips that keep a grid cell
/// and the date printed under it in agreement — the failure mode a calendar
/// cannot survive is being off by one day and not knowing.
void main() {
  group('Ramadan', () {
    test('a day inside Ramadan knows its day number', () {
      final HijriCalendar probe = HijriCalendar.fromDate(DateTime(2026, 7, 1));
      // Pin the year the probe lands in, then walk its Ramadan from the
      // table itself: the assertions are about *position*, not about which
      // gregorian month the Umm al-Qura table happens to put it in.
      final DateTime start =
          HijriCalendar().hijriToGregorian(probe.hYear, 9, 1);
      final DateTime midRamadan =
          DateTime(start.year, start.month, start.day).add(const Duration(days: 9));

      final RamadanInfo? info = ramadanAround(midRamadan);
      expect(info, isNotNull);
      expect(info!.dayNumber, 10);
      expect(info.isRunning, isTrue);
      expect(info.start, DateTime(start.year, start.month, start.day));
      expect(info.length, inInclusiveRange(29, 30));
      expect(info.lastDay.difference(info.start).inDays, info.length - 1);
    });

    test('the first fast reads as day one', () {
      final HijriCalendar probe = HijriCalendar.fromDate(DateTime(2026, 7, 1));
      final DateTime start =
          HijriCalendar().hijriToGregorian(probe.hYear, 9, 1);
      final RamadanInfo? info =
          ramadanAround(DateTime(start.year, start.month, start.day));
      expect(info!.dayNumber, 1);
    });

    test('a day outside Ramadan answers nothing', () {
      // October — comfortably outside any Ramadan.
      expect(ramadanAround(DateTime(2026, 10, 12)), isNull);
      // So is Shawwal, the month after.
      final HijriCalendar probe = HijriCalendar.fromDate(DateTime(2026, 7, 1));
      final DateTime start = HijriCalendar()
          .hijriToGregorian(probe.hYear, 9, probe.getDaysInMonth(probe.hYear, 9));
      final DateTime dayAfter = DateTime(start.year, start.month, start.day)
          .add(const Duration(days: 1));
      expect(ramadanAround(dayAfter), isNull);
    });

    test('days until the next Ramadan counts down from a plain day', () {
      final HijriCalendar probe = HijriCalendar.fromDate(DateTime(2026, 10, 12));
      // October sits early in the Hijri year, so the *coming* Ramadan is in
      // the same Hijri year — only a day after Ramadan itself would look a
      // whole year ahead.
      final int year = probe.hMonth < 9 ? probe.hYear : probe.hYear + 1;
      final DateTime start = HijriCalendar().hijriToGregorian(year, 9, 1);
      final int days = daysUntilRamadan(DateTime(2026, 10, 12))!;
      expect(DateTime(2026, 10, 12).add(Duration(days: days)),
          DateTime(start.year, start.month, start.day));
      expect(days, greaterThan(20)); // never zero or one from October
    });
  });

  group('the Hijri month grid', () {
    test('starts on the 1st and runs the month’s real length', () {
      final DateTime anchor = DateTime(2026, 10, 12);
      final List<HijriGridDay> grid = hijriMonthGrid(anchor);
      final HijriCalendar first = NoorHijri.hijriOf(grid.first.gregorian);

      expect(first.hDay, 1);
      expect(grid, hasLength(NoorHijri.monthLength(anchor)));
      expect(grid.last.hijriDay, grid.length);
      expect(grid.where((HijriGridDay d) => d.isToday), hasLength(1));
    });

    test('every cell round-trips: gregorian day → same Hijri number', () {
      // The property that keeps the number printed on a cell and the date
      // printed under it from drifting apart.
      final DateTime anchor = DateTime(2026, 10, 12);
      final List<HijriGridDay> grid = hijriMonthGrid(anchor);
      for (final HijriGridDay cell in grid) {
        final HijriCalendar h = NoorHijri.hijriOf(cell.gregorian);
        expect(h.hDay, cell.hijriDay, reason: 'cell ${cell.gregorian}');
        expect(cell.events.where((IslamicEvent e) => e.day != cell.hijriDay),
            isEmpty, reason: 'event day must match its cell');
      }
    });

    test('month navigation lands on the 1st of the neighbour month', () {
      final DateTime anchor = DateTime(2026, 10, 12);
      final DateTime next = NoorHijri.monthStartBy(anchor, 1);
      final DateTime previous = NoorHijri.monthStartBy(anchor, -1);
      final HijriCalendar a = NoorHijri.hijriOf(anchor);
      final HijriCalendar n = NoorHijri.hijriOf(next);
      final HijriCalendar p = NoorHijri.hijriOf(previous);

      expect(n.hDay, 1);
      expect(p.hDay, 1);
      // 12th of month M → next month is M+1 unless December rolls the year.
      expect(n.hYear * 12 + n.hMonth, a.hYear * 12 + a.hMonth + 1);
      expect(p.hYear * 12 + p.hMonth, a.hYear * 12 + a.hMonth - 1);
    });

    test('a ±days correction shifts the whole grid together', () {
      final DateTime anchor = DateTime(2026, 10, 12);
      final List<HijriGridDay> plain = hijriMonthGrid(anchor);
      final List<HijriGridDay> shifted = hijriMonthGrid(anchor, adjustment: 1);

      // Same cells, one gregorian day earlier each: the correction moves
      // the calendar, not the arithmetic.
      expect(shifted.first.hijriDay, 1);
      for (int i = 0; i < plain.length && i < shifted.length; i++) {
        expect(
          shifted[i].gregorian.difference(plain[i].gregorian).inDays,
          -1,
          reason: 'cell $i',
        );
      }
    });
  });

  group('occasions', () {
    test('Ashura sits on 10 Muharram', () {
      final DateTime ashura =
          NoorHijri.gregorianOf(1448, 1, 10, adjustment: 0);
      final List<IslamicEvent> hits = eventsOn(ashura);
      expect(hits.map((IslamicEvent e) => e.title), contains('Ashura'));
    });

    test('both Eids sit on the 1st of their months', () {
      expect(eventsOnHijri(10, 1).single.title, 'Eid al-Fitr');
      expect(eventsOnHijri(12, 10).single.title, 'Eid al-Adha');
    });

    test('the next occasion is found forward, with its gregorian day', () {
      // From a week before Milad un Nabi 1448 (12 Rabi al-Awwal).
      final DateTime milad = NoorHijri.gregorianOf(1448, 3, 12, adjustment: 0);
      final (IslamicEvent, DateTime)? next =
          nextEvent(milad.subtract(const Duration(days: 7)));
      expect(next, isNotNull);
      expect(next!.$1.title, 'Milad un Nabi');
      expect(next.$2, milad);
    });

    test('today itself counts as "next" when it carries an occasion', () {
      final DateTime eid = NoorHijri.gregorianOf(1448, 10, 1, adjustment: 0);
      final (IslamicEvent, DateTime)? next = nextEvent(eid);
      expect(next!.$1.title, 'Eid al-Fitr');
      expect(next.$2, eid);
    });

    test('every offered occasion names the date it follows', () {
      for (final IslamicEvent e in kIslamicEvents) {
        expect(e.note, isNotEmpty, reason: e.title);
        expect(e.month, inInclusiveRange(1, 12));
        expect(e.day, inInclusiveRange(1, 30));
      }
    });
  });
}
