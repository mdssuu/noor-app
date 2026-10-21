import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/prayer_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<PrayerTracker> fresh() async {
    final PrayerTracker t = PrayerTracker.test();
    await t.load();
    return t;
  }

  group('logging one prayer', () {
    test('an offering appears, a second tap takes it back', () async {
      final PrayerTracker t = await fresh();
      final DateTime day = DateTime(2026, 10, 12);

      t.toggle(day, 'fajr');
      expect(t.isPrayed(day, 'fajr'), isTrue);
      expect(t.day(day), <String>{'fajr'});

      t.toggle(day, 'fajr');
      expect(t.isPrayed(day, 'fajr'), isFalse);
      expect(t.day(day), isEmpty, reason: 'an empty day leaves no trace');
    });

    test('marking today complete fills all five', () async {
      final PrayerTracker t = await fresh();
      t.markTodayComplete();
      final DateTime now = DateTime.now();
      for (final String prayer in kNotifiablePrayers) {
        expect(t.isPrayed(now, prayer), isTrue, reason: prayer);
      }
    });
  });

  group('the streak', () {
    // The rule under test: a chain counts complete days, and today is only
    // allowed to break it once it is itself complete — before that, the
    // chain is measured from yesterday and today can still extend it.
    DateTime day(int daysAgo, {DateTime? from}) {
      final DateTime base = from ?? DateTime(2026, 10, 12);
      return DateTime(base.year, base.month, base.day)
          .subtract(Duration(days: daysAgo));
    }

    test('nothing logged is no streak', () {
      expect(
        PrayerTracker.streakOf(<String, Set<String>>{},
            today: DateTime(2026, 10, 12)),
        0,
      );
    });

    test('one complete day is a streak of one', () {
      final Map<String, Set<String>> log = <String, Set<String>>{
        PrayerTracker.stamp(day(0)): kNotifiablePrayers.toSet(),
      };
      expect(PrayerTracker.streakOf(log, today: DateTime(2026, 10, 12)), 1);
    });

    test('an unbroken run counts back', () {
      final Map<String, Set<String>> log = <String, Set<String>>{};
      for (int i = 0; i < 5; i++) {
        log[PrayerTracker.stamp(day(i))] = kNotifiablePrayers.toSet();
      }
      // One prayer short on an older day stops the run there.
      log[PrayerTracker.stamp(day(5))] = <String>{'fajr', 'dhuhr'};
      expect(PrayerTracker.streakOf(log, today: DateTime(2026, 10, 12)), 5);
    });

    test('today in progress does not break yesterday’s chain', () {
      // It is 6 a.m.: Fajr has not come in, and the log says so. The chain
      // from yesterday must still read as alive.
      final Map<String, Set<String>> log = <String, Set<String>>{
        PrayerTracker.stamp(day(1)): kNotifiablePrayers.toSet(),
        PrayerTracker.stamp(day(2)): kNotifiablePrayers.toSet(),
        PrayerTracker.stamp(day(0)): <String>{'fajr'},
      };
      expect(PrayerTracker.streakOf(log, today: DateTime(2026, 10, 12)), 2);
    });

    test('a gap breaks the chain', () {
      final Map<String, Set<String>> log = <String, Set<String>>{
        PrayerTracker.stamp(day(0)): kNotifiablePrayers.toSet(),
        // yesterday: nothing
        PrayerTracker.stamp(day(2)): kNotifiablePrayers.toSet(),
      };
      expect(PrayerTracker.streakOf(log, today: DateTime(2026, 10, 12)), 1);
    });
  });

  group('a month’s totals', () {
    test('counts the days, the complete days and each prayer', () {
      final Map<String, Set<String>> log = <String, Set<String>>{
        '2026-10-01': kNotifiablePrayers.toSet(),
        '2026-10-02': kNotifiablePrayers.toSet(),
        '2026-10-03': <String>{'fajr', 'isha'},
        '2026-09-30': kNotifiablePrayers.toSet(), // last month — excluded
      };
      final MonthSummary m = PrayerTracker.monthSummary(log,
          year: 2026, month: 10, today: DateTime(2026, 10, 31));

      expect(m.daysLogged, 3);
      expect(m.daysComplete, 2);
      expect(m.perPrayer['fajr'], 3);
      expect(m.perPrayer['isha'], 3);
      expect(m.perPrayer['asr'], 2);
      expect(m.perPrayer['maghrib'], 2);
    });

    test('days not yet reached are not counted against the month', () {
      final Map<String, Set<String>> log = <String, Set<String>>{};
      final MonthSummary m = PrayerTracker.monthSummary(log,
          year: 2026, month: 10, today: DateTime(2026, 10, 12));
      expect(m.daysLogged, 0);
      expect(m.daysComplete, 0);
    });
  });

  group('the whole log', () {
    test('encodes and reads back through the service', () async {
      final PrayerTracker t = await fresh();
      t.toggle(DateTime(2026, 10, 12), 'fajr');
      t.toggle(DateTime(2026, 10, 12), 'dhuhr');
      await Future<void>.delayed(Duration.zero); // fire-and-forget persist

      final PrayerTracker reloaded = await fresh();
      expect(reloaded.day(DateTime(2026, 10, 12)), <String>{'dhuhr', 'fajr'});
    });

    test('a stamp round-trips through its day', () {
      final DateTime day = DateTime(2026, 1, 5);
      expect(PrayerTracker.stamp(day), '2026-01-05');
      expect(PrayerTracker.dayOf('2026-01-05'), day);
      // A malformed stamp answers "today" rather than throwing — this runs
      // against stored text a hand may have edited.
      expect(PrayerTracker.dayOf('garbage'), isNotNull);
    });
  });
}
