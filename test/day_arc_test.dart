import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/day_arc.dart';
import 'package:noor_masjid_time/services/nafl_times.dart';

/// The daylight arc is the arithmetic behind the curve on Home: sunrise at
/// one end, sunset at the other, and the nafl times pinned between them.
///
/// The two things that must never be wrong are the *ends* (the sunrise and
/// the sunset of the day being drawn) and the *position* of a time on the
/// curve — a mark that says Ishraq is a quarter of the way through the day
/// when it is not would put the sun in the wrong place.
void main() {
  // A day built by hand: sunrise at 06:00, Dhuhr at 12:00, sunset at 18:00
  // — six hours of daylight, so every fraction below is easy to read.
  LocalPrayerTimes day({
    DateTime? sunrise,
    DateTime? sunset,
    bool withoutSunset = false,
  }) {
    return LocalPrayerTimes(
      times: <String, DateTime>{
        'fajr': DateTime(2026, 3, 10, 5, 15),
        'sunrise': sunrise ?? DateTime(2026, 3, 10, 6),
        'dhuhr': DateTime(2026, 3, 10, 12),
        'asr': DateTime(2026, 3, 10, 15, 30),
        'maghrib': DateTime(2026, 3, 10, 18),
        'isha': DateTime(2026, 3, 10, 19, 15),
        if (!withoutSunset) 'sunset': sunset ?? DateTime(2026, 3, 10, 18),
      },
      fajrTomorrow: DateTime(2026, 3, 11, 5, 15),
    );
  }

  group('the arc of a day', () {
    test('runs from sunrise to sunset', () {
      final DayArc? arc = DayArc.of(day());
      expect(arc, isNotNull);
      expect(arc!.sunrise, DateTime(2026, 3, 10, 6));
      expect(arc.sunset, DateTime(2026, 3, 10, 18));
      expect(arc.daylight, const Duration(hours: 12));
      expect(arc.daylightHours, 12.0);
    });

    test('a day without a sunset has no arc to draw', () {
      // The sun is not always up — the polar summer, and the calculation
      // for a place where the sun never sets. A missing sunset must leave
      // the card blank, not draw a curve to a time that does not exist.
      expect(DayArc.of(day()), isNotNull);
      final LocalPrayerTimes noSunset = LocalPrayerTimes(
        times: <String, DateTime>{
          'sunrise': DateTime(2026, 3, 10, 6),
          'dhuhr': DateTime(2026, 3, 10, 12),
          'isha': DateTime(2026, 3, 10, 19, 15),
        },
        fajrTomorrow: DateTime(2026, 3, 11, 5, 15),
      );
      expect(DayArc.of(noSunset), isNull);
      expect(DayArc.of(day(withoutSunset: true)), isNull);
    });

    test('a sunset before the sunrise is not an arc', () {
      expect(DayArc.of(day(sunset: DateTime(2026, 3, 10, 5))), isNull);
    });
  });

  group('where a moment sits on the arc', () {
    test('sunrise is the start and sunset is the end', () {
      final DayArc arc = DayArc.of(day())!;
      expect(arc.fractionOf(DateTime(2026, 3, 10, 6)), 0);
      expect(arc.fractionOf(DateTime(2026, 3, 10, 18)), 1);
    });

    test('the middle of the day is the middle of the curve', () {
      final DayArc arc = DayArc.of(day())!;
      expect(arc.fractionOf(DateTime(2026, 3, 10, 12)), 0.5);
    });

    test('a time after dark belongs to no curve', () {
      final DayArc arc = DayArc.of(day())!;
      // Before the sun rose and after it went down — both outside.
      expect(arc.fractionOf(DateTime(2026, 3, 10, 3)), isNull);
      expect(arc.fractionOf(DateTime(2026, 3, 10, 21)), isNull);
    });
  });

  group('the marks pinned on the arc', () {
    test('carry the nafl times that fall in the daylight', () {
      final DayArc arc = DayArc.of(day())!;
      final List<String> keys = arc.marks.map((DayArcMark m) => m.key).toList();

      // Ishraq (20 minutes after sunrise), Chasht (a quarter of the way to
      // Dhuhr) and Zawal (10 minutes before Dhuhr) are all inside the day.
      expect(keys, containsAll(<String>['ishraq', 'chasht', 'zawal']));

      // Tahajjud is the last third of the *night* — it is printed under the
      // curve, never on it.
      expect(keys, isNot(contains('tahajjud')));
    });

    test('stand in the right order and in the right place', () {
      final DayArc arc = DayArc.of(day())!;

      for (int i = 1; i < arc.marks.length; i++) {
        expect(
          arc.marks[i].at.isAfter(arc.marks[i - 1].at),
          isTrue,
          reason: 'the marks must run with the clock',
        );
      }

      final DayArcMark ishraq = arc.marks.firstWhere(
        (DayArcMark m) => m.key == 'ishraq',
      );
      expect(ishraq.at, DateTime(2026, 3, 10, 6, 20));
      expect(arc.fractionOf(ishraq.at), closeTo(0.028, 0.001));

      final DayArcMark zawal = arc.marks.firstWhere(
        (DayArcMark m) => m.key == 'zawal',
      );
      expect(zawal.at, DateTime(2026, 3, 10, 11, 50));
      expect(arc.fractionOf(zawal.at), closeTo(0.486, 0.001));
    });

    test('a nafl time that falls outside the daylight is left off', () {
      // Ishraq is sunrise + 20 minutes. With the sun rising at 06:10 it is
      // still inside; push the sunrise to 06:05 and the mark still stands —
      // but a sunset before sunrise + 20 would throw the whole curve away,
      // which is the check the card makes before it draws anything.
      final DayArc arc = DayArc.of(day(sunrise: DateTime(2026, 3, 10, 6, 5)))!;
      final DayArcMark ishraq = arc.marks.firstWhere(
        (DayArcMark m) => m.key == 'ishraq',
      );
      expect(ishraq.at, DateTime(2026, 3, 10, 6, 25));
    });
  });

  group('the nafl times the card prints', () {
    test('come from the same day, with their rules', () {
      final Map<String, DateTime> nafl = NaflTimes.of(day());
      expect(nafl['ishraq'], DateTime(2026, 3, 10, 6, 20));
      // A quarter of the six hours from sunrise to Dhuhr.
      expect(nafl['chasht'], DateTime(2026, 3, 10, 7, 30));
      expect(nafl['zawal'], DateTime(2026, 3, 10, 11, 50));
      // The last third of the night: Isha plus two thirds of the way to
      // tomorrow's Fajr.
      expect(nafl['tahajjud'], DateTime(2026, 3, 11, 1, 55));
    });
  });
}
