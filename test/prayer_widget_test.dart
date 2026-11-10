import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor_masjid_time/app_settings.dart';
import 'package:noor_masjid_time/prayer_readings.dart';
import 'package:noor_masjid_time/services/prayer_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The picture the home-screen widget is fed — the structure the Kotlin
/// side reads field by field, so a rename on either side has to show up
/// here first.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.instance.load();
  });

  final Map<String, Object?> payload = PrayerWidget.buildPayload(
    latitude: 19.0760,
    longitude: 72.8777,
    areaName: 'Kurla',
    now: DateTime(2026, 10, 12, 10, 30),
    hijriAdjustment: 0,
  );

  group('the prepared picture', () {
    test('carries the place and both calendars', () {
      expect(payload['city'], 'Kurla');
      expect(payload['dateLabel'], 'Mon, 12 Oct');
      expect(payload['hijri'], isNot(isEmpty),
          reason: 'the Hijri line is a headline field, not optional');
    });

    test('lists today’s six times, labelled for a human', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      expect(prayers, hasLength(6));
      expect(prayers.first['label'], 'Fajr');
      expect(prayers.last['label'], 'Isha');
      // Sunrise is not one of the five — the widget must not present it as
      // a prayer to be offered, only as the light coming up.
      expect(
        prayers.where((Map<String, Object?> p) => p['label'] == 'Sunrise'),
        hasLength(1),
      );
      for (final Map<String, Object?> p in prayers) {
        expect(p['time'], isNot(isEmpty), reason: '${p['label']} needs a clock');
      }
    });

    test('the transition table runs two days, ascending', () {
      final List<Map<String, Object?>> transitions =
          (payload['transitions']! as List).cast<Map<String, Object?>>();
      expect(transitions, hasLength(10), reason: 'five prayers × two days');
      expect(transitions.first['label'], 'Fajr');
      expect(transitions[5]['label'], 'Fajr', reason: 'tomorrow starts over');

      int previous = 0;
      for (final Map<String, Object?> t in transitions) {
        final int at = t['atMs']! as int;
        expect(at, greaterThan(previous), reason: 'instants must ascend');
        previous = at;
        expect(t['time'], isNot(isEmpty));
      }
    });

    test('survives the trip across the channel as JSON', () {
      final String wire = jsonEncode(payload);
      final Map<String, Object?> back =
          (jsonDecode(wire) as Map).cast<String, Object?>();
      expect(back['city'], 'Kurla');
      expect((back['transitions']! as List), hasLength(10));
    });

    test('names every row by key so the Kotlin side can find it', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      for (final Map<String, Object?> p in prayers) {
        expect(p['key'], isNot(isEmpty),
            reason: 'rows are found by key, not by a human label');
      }
      expect(prayers.map((Map<String, Object?> p) => p['key']),
          containsAll(<String>['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha']));
    });
  });

  group('the reading under each prayer', () {
    test('is today’s pool entry in the reader’s language', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      final String lang = AppSettings.instance.readingLanguage;
      for (final Map<String, Object?> p in prayers) {
        if (p['key'] == 'sunrise') continue;
        final PrayerReading expected =
            readingFor(p['key']! as String, DateTime(2026, 10, 12));
        expect(p['quote'], expected.translationFor(lang),
            reason: '${p['key']} must show its own day’s reading');
        expect(p['source'], expected.source);
      }
    });

    test('is absent for sunrise — the light is not a prayer', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      final Map<String, Object?> rise = prayers
          .firstWhere((Map<String, Object?> p) => p['key'] == 'sunrise');
      expect(rise.containsKey('quote'), isFalse);
      expect(rise.containsKey('source'), isFalse);
    });

    test('tomorrow’s twin travels alongside it', () {
      final List<Map<String, Object?>> prayers =
          (payload['prayers']! as List).cast<Map<String, Object?>>();
      final String lang = AppSettings.instance.readingLanguage;
      final DateTime tomorrow = DateTime(2026, 10, 13);
      for (final Map<String, Object?> p in prayers) {
        expect(p['tomorrowTime'], isNot(isEmpty),
            reason: 'after midnight the clock must still have a value');
        if (p['key'] == 'sunrise') continue;
        final PrayerReading expected =
            readingFor(p['key']! as String, tomorrow);
        expect(p['tomorrowQuote'], expected.translationFor(lang));
        expect(p['tomorrowSource'], expected.source);
      }
    });

    test('the payload says when tomorrow starts', () {
      // Local midnight ending the prepared day — the instant the Kotlin
      // side must switch every row to its tomorrow twin.
      final int dayEnd = payload['dayEndMs']! as int;
      expect(dayEnd, DateTime(2026, 10, 13).millisecondsSinceEpoch);
      expect(payload['dateLabelTomorrow'], 'Tue, 13 Oct');
      expect(payload['hijriTomorrow'], isNot(isEmpty));
      expect(payload['readingLang'], AppSettings.instance.readingLanguage);
    });

    test('and the whole picture survives the channel as JSON', () {
      final Map<String, Object?> back =
          (jsonDecode(jsonEncode(payload)) as Map).cast<String, Object?>();
      expect(back['dayEndMs'], payload['dayEndMs']);
      expect(back['readingLang'], payload['readingLang']);
      final List<Map<String, Object?>> prayers =
          (back['prayers']! as List).cast<Map<String, Object?>>();
      expect(prayers.first['quote'], isNot(isEmpty));
    });
  });

  test('tomorrow’s Fajr is in the table tonight', () {
    // At 23:30 every of *today's* entries is behind the clock — without
    // tomorrow's copy the widget would have nothing true left to say.
    final Map<String, Object?> late = PrayerWidget.buildPayload(
      latitude: 19.0760,
      longitude: 72.8777,
      areaName: 'Kurla',
      now: DateTime(2026, 10, 12, 23, 30),
    );
    final List<Map<String, Object?>> transitions =
        (late['transitions']! as List).cast<Map<String, Object?>>();
    final int now = DateTime(2026, 10, 12, 23, 30).millisecondsSinceEpoch;
    expect(
      transitions.where((Map<String, Object?> t) => (t['atMs']! as int) > now),
      isNotEmpty,
      reason: 'something must still be ahead of the clock',
    );
  });
}
