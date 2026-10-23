import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/services/nafl_times.dart';

void main() {
  // A day built by hand rather than by the engine: these rules are about
  // *where* in the day the times sit, and a hand-built day pins them to the
  // minute so a drifting calculation method cannot muddy the assertion.
  LocalPrayerTimes day({
    required DateTime sunrise,
    required DateTime dhuhr,
    required DateTime isha,
    required DateTime fajrTomorrow,
  }) =>
      LocalPrayerTimes(
        times: <String, DateTime>{
          'fajr': fajrTomorrow.subtract(const Duration(days: 1)),
          'sunrise': sunrise,
          'dhuhr': dhuhr,
          'asr': sunrise.add(const Duration(hours: 7)),
          'maghrib': isha.subtract(const Duration(minutes: 20)),
          'isha': isha,
        },
        fajrTomorrow: fajrTomorrow,
      );

  final LocalPrayerTimes mumbaiLike = day(
    sunrise: DateTime(2026, 10, 12, 5, 30),
    dhuhr: DateTime(2026, 10, 12, 12, 30),
    isha: DateTime(2026, 10, 12, 20, 0),
    fajrTomorrow: DateTime(2026, 10, 13, 5, 30),
  );

  group('the four nafl times', () {
    final Map<String, DateTime> nafl = NaflTimes.of(mumbaiLike);

    test('Ishraq is twenty minutes after sunrise', () {
      expect(nafl['ishraq'], DateTime(2026, 10, 12, 5, 50));
    });

    test('Chasht is a quarter of the way from sunrise to Dhuhr', () {
      // 05:30 → 12:30 is seven hours; a quarter is 1 h 45 m.
      expect(nafl['chasht'], DateTime(2026, 10, 12, 7, 15));
    });

    test('Zawal begins ten minutes before Dhuhr', () {
      expect(nafl['zawal'], DateTime(2026, 10, 12, 12, 20));
    });

    test('Tahajjud is the last third of the night', () {
      // Isha 20:00 → Fajr 05:30 is 9 h 30 m; two thirds is 6 h 20 m, so the
      // last third begins at 02:20 the next morning.
      expect(nafl['tahajjud'], DateTime(2026, 10, 13, 2, 20));
      expect(nafl['tahajjud']!.isAfter(DateTime(2026, 10, 12, 20, 0)), isTrue);
      expect(
          nafl['tahajjud']!.isBefore(DateTime(2026, 10, 13, 5, 30)), isTrue);
    });
  });

  test('a day missing its anchors yields nothing rather than exceptions', () {
    final LocalPrayerTimes broken = LocalPrayerTimes(
      times: <String, DateTime>{'fajr': DateTime(2026, 10, 12, 5, 30)},
      fajrTomorrow: DateTime(2026, 10, 13, 5, 30),
    );
    expect(NaflTimes.of(broken), isEmpty);
  });

  test('every offered time carries the rule it follows', () {
    expect(kNaflTimes, hasLength(4));
    for (final NaflTime t in kNaflTimes) {
      expect(t.hint, isNotEmpty, reason: '${t.key} must explain itself');
      expect(naflByKey(t.key).key, t.key);
    }
    // An unknown key is a display bug, not a crash.
    expect(naflByKey('nonsense').key, kNaflTimes.first.key);
  });
}
